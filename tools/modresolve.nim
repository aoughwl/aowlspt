## modresolve -- the mod manager's rules, checked without a server.
##
##     modresolve            every check
##     modresolve -q         failures only
##
## `livectl` proves that turning a mod off turns it off in a running host. That
## needs a backend, three built mods, a port and about twelve seconds, so it is
## a test people run when they remember to. This one needs a process and eight
## milliseconds, because everything it checks is a function of its arguments:
##
##  * `mgr/resolve.nim` -- the ten verdicts, over registries built in memory,
##  * `mgr/registry.nim` -- what a manifest with something wrong in it produces,
##  * `mgr/semver.nim` -- versions and ranges,
##  * `mgr/selection.nim`'s reader -- what a damaged selection file does.
##
## It imports those modules directly rather than driving them over HTTP, which
## is what makes it exhaustive rather than sampled: a resolver case is four
## lines here and a staged install there.
##
## ## What is being pinned, and why each one is here
##
## **The resolver is a function.** Same registry, same selection, same side,
## same host version, same answer -- so every check below is an equality on a
## verdict, an order or a problem string, and the last one runs the same input
## twice and compares.
##
## **A failure is reported, never repaired.** Half of these check the *reason*
## rather than the verdict. A resolver that excludes the right mod for a reason
## it cannot state is one nobody can act on at two in the morning, and the
## reason is the whole product.
##
## **A cycle is refused by name.** Four kinds -- a list inheriting itself, two
## lists inheriting each other, a `requires` cycle, a `loadAfter` cycle -- and
## each one has to come back with the cycle named in `problems`. Not hang, and
## not quietly drop a mod: an infinite loop in here is a server that stops
## answering, and a silently dropped mod is a mod list that is not the one
## anybody chose.
##
## **A damaged selection is refused loudly.** The store can tell "nothing
## saved" from "there is something saved and it could not be read"
## (`Stored.missing`), and the difference decides whether the manager seeds the
## defaults or refuses to write at all. The reader that makes that call is pure
## and is driven here with every shape of damage: empty, truncated mid-array,
## trailing bytes, a NUL in the middle, an object that is not a selection.
## "The manager silently forgot my setup" is the bug that cannot be debugged
## afterwards, so it is checked before it can happen rather than after.

import std/[strutils, syncio, cmdline]
import aowlsptinstall/log
import registry
import resolve
import aowlspt/semver
import selection

var gFailures = 0
var gChecks = 0
var gQuiet = false

proc check(what: string; condition: bool; detail = "") =
  inc gChecks
  if condition:
    if not gQuiet:
      ok what
  else:
    err what & (if detail.len > 0: ": " & detail else: "")
    inc gFailures

proc checkEq(what, got, want: string) =
  check(what, got == want, "got \"" & got & "\", wanted \"" & want & "\"")

# ---------------------------------------------------------------------------
# Building registries in memory
# ---------------------------------------------------------------------------
#
# Full constructors rather than defaults with mutation afterwards: a fixture
# that is assembled in six statements is a fixture whose sixth statement can be
# forgotten, and a resolver check against a mod that was not the mod the reader
# thinks it was passes for the wrong reason.

proc aMod(id, version, pipeline: string; sides: seq[string]): ModEntry =
  result = ModEntry(id: id, name: id & " (name)", author: "test",
                    version: version, description: "", pipeline: pipeline,
                    sides: sides, sourceKind: "intree", sourcePath: "",
                    sourceUrl: "", artifactDir: id, artifactLib: id & ".dll",
                    license: "", downloadUrl: "", downloadHash: "",
                    requires: @[], conflicts: @[], provides: @[],
                    loadAfter: @[], tags: @[])

proc serverMod(id: string): ModEntry =
  result = aMod(id, "1.0.0", "*", @["server"])

proc entry(id: string; enabled: bool): ListEntry =
  result = ListEntry(id: id, enabled: enabled, note: "")

proc aList(id: string; inherits: seq[string];
           entries: seq[ListEntry]): ModList =
  result = ModList(id: id, name: id, author: "", version: "1.0.0",
                   description: "", inherits: inherits, entries: entries,
                   local: false)

proc emptyReg(): Registry =
  result = Registry(ok: true, path: "test-registry", error: "", name: "test",
                    warnings: @[], mods: @[], lists: @[])

proc noOverrides(): seq[string] = @[]
proc noFlags(): seq[bool] = @[]

proc run(reg: Registry; lists: seq[string]): Resolution =
  result = resolve(reg, lists, noOverrides(), noFlags(), "server", "0.1.0")

proc runWith(reg: Registry; lists, ovIds: seq[string];
             ovOn: seq[bool]): Resolution =
  result = resolve(reg, lists, ovIds, ovOn, "server", "0.1.0")

# ---------------------------------------------------------------------------
# Reading a resolution
# ---------------------------------------------------------------------------

proc verdictOf(r: Resolution; id: string): string =
  ## The verdict for one mod, or "absent" when the resolver said nothing about
  ## it at all -- which is itself a failure worth being able to see, because
  ## every mod in the registry is supposed to come back with a decision.
  var i = -1
  if not decisionFor(r, id, i):
    return "absent"
  result = verdictName(r.decisions[i].verdict)

proc reasonOf(r: Resolution; id: string): string =
  var i = -1
  if not decisionFor(r, id, i):
    return ""
  result = r.decisions[i].reason

proc fromListOf(r: Resolution; id: string): string =
  var i = -1
  if not decisionFor(r, id, i):
    return ""
  result = r.decisions[i].fromList

proc orderText(r: Resolution): string =
  result = ""
  for id in r.order:
    if result.len > 0: result.add ","
    result.add id

proc problemsText(r: Resolution): string =
  result = ""
  for p in r.problems:
    if result.len > 0: result.add " | "
    result.add p

proc says(r: Resolution; needle: string): bool =
  result = find(problemsText(r), needle) >= 0

proc warningsText(reg: Registry): string =
  result = ""
  for w in reg.warnings:
    if result.len > 0: result.add " | "
    result.add w

# ---------------------------------------------------------------------------
# 1. The plain cases
# ---------------------------------------------------------------------------

proc theBasics() =
  heading "One list, and what it says about every mod"
  var reg = emptyReg()
  reg.mods.add serverMod("a")
  reg.mods.add serverMod("b")
  reg.mods.add serverMod("c")
  reg.lists.add aList("l", @[], @[entry("a", true), entry("b", false)])
  let r = run(reg, @["l"])
  checkEq("a list entry that is on loads", verdictOf(r, "a"), "loaded")
  checkEq("a list entry that is off is disabled", verdictOf(r, "b"), "disabled")
  checkEq("and says which list turned it off", reasonOf(r, "b"),
          "turned off by l")
  checkEq("a mod no list mentions is not-selected", verdictOf(r, "c"),
          "not-selected")
  checkEq("the order is what loaded, and nothing else", orderText(r), "a")
  check("a decision comes back for every mod in the registry",
        r.decisions.len == 3, $r.decisions.len & " decisions for 3 mods")
  checkEq("and the loaded one carries its position", $r.decisions[0].order, "0")

  heading "An id the registry does not have"
  var reg2 = emptyReg()
  reg2.mods.add serverMod("a")
  reg2.lists.add aList("l", @[], @[entry("a", true), entry("ghost", true)])
  let r2 = run(reg2, @["l"])
  checkEq("a list naming a mod that is not there is unknown",
          verdictOf(r2, "ghost"), "unknown")
  check("and says where it looked", find(reasonOf(r2, "ghost"),
        "test-registry") >= 0, reasonOf(r2, "ghost"))
  checkEq("and it stops nothing else", orderText(r2), "a")

  heading "A list that does not exist"
  let r3 = run(reg2, @["l", "nosuchlist"])
  check("naming a list nothing defines is a problem, by name",
        r3.says("no list called nosuchlist"), problemsText(r3))
  checkEq("and the lists that do exist still resolve", orderText(r3), "a")

# ---------------------------------------------------------------------------
# 2. Inheritance and merging
# ---------------------------------------------------------------------------

proc inheritance() =
  heading "A parent's entries come first, and a child may flip them"
  var reg = emptyReg()
  reg.mods.add serverMod("a")
  reg.mods.add serverMod("b")
  reg.mods.add serverMod("c")
  reg.lists.add aList("parent", @[], @[entry("a", true), entry("b", true)])
  reg.lists.add aList("child", @["parent"],
                      @[entry("c", true), entry("b", false)])
  let r = run(reg, @["child"])
  checkEq("the parent's entries lead the order", orderText(r), "a,c")
  checkEq("the child's own entry is on", verdictOf(r, "c"), "loaded")
  checkEq("the child turns the parent's entry off", verdictOf(r, "b"),
          "disabled")
  checkEq("and the child is named as the one that did it", fromListOf(r, "b"),
          "child")

  heading "A later entry updates the flag and does not move the mod"
  var reg2 = emptyReg()
  reg2.mods.add serverMod("a")
  reg2.mods.add serverMod("b")
  reg2.lists.add aList("parent", @[], @[entry("a", false), entry("b", true)])
  reg2.lists.add aList("child", @["parent"], @[entry("a", true)])
  let r2 = run(reg2, @["child"])
  checkEq("the re-enabled mod keeps the parent's position, not the child's",
          orderText(r2), "a,b")

  heading "A diamond is not a cycle"
  var reg3 = emptyReg()
  reg3.mods.add serverMod("a")
  reg3.mods.add serverMod("b")
  reg3.lists.add aList("base", @[], @[entry("a", true)])
  reg3.lists.add aList("left", @["base"], @[])
  reg3.lists.add aList("right", @["base"], @[entry("b", true)])
  reg3.lists.add aList("top", @["left", "right"], @[])
  let r3 = run(reg3, @["top"])
  checkEq("two lists inheriting one parent resolve normally",
          orderText(r3), "a,b")
  check("and nothing is reported as a cycle",
        not r3.says("cycle"), problemsText(r3))

  heading "Two active lists, in the order the selection gives them"
  var reg4 = emptyReg()
  reg4.mods.add serverMod("a")
  reg4.lists.add aList("first", @[], @[entry("a", true)])
  reg4.lists.add aList("second", @[], @[entry("a", false)])
  let r4 = run(reg4, @["first", "second"])
  checkEq("the later list's flag wins", verdictOf(r4, "a"), "disabled")
  let r5 = run(reg4, @["second", "first"])
  checkEq("and swapping them swaps the answer", verdictOf(r5, "a"), "loaded")

# ---------------------------------------------------------------------------
# 3. The user's own overrides
# ---------------------------------------------------------------------------

proc overrides() =
  heading "An override beats every list"
  var reg = emptyReg()
  reg.mods.add serverMod("a")
  reg.mods.add serverMod("b")
  reg.mods.add serverMod("outside")
  reg.lists.add aList("l", @[], @[entry("a", true), entry("b", false)])

  let off = runWith(reg, @["l"], @["a"], @[false])
  checkEq("an override off beats a list that says on", verdictOf(off, "a"),
          "disabled")
  checkEq("and says it was you", reasonOf(off, "a"), "you turned it off")
  check("and is marked explicit", off.decisions[0].explicit, "not explicit")

  let on = runWith(reg, @["l"], @["b"], @[true])
  checkEq("an override on beats a list that says off", verdictOf(on, "b"),
          "loaded")

  let added = runWith(reg, @["l"], @["outside"], @[true])
  checkEq("an override adds a mod no active list mentions, at the end",
          orderText(added), "a,outside")

  let ghost = runWith(reg, @["l"], @["nosuchmod"], @[true])
  checkEq("an override naming a mod that is not in the registry is unknown",
          verdictOf(ghost, "nosuchmod"), "unknown")
  checkEq("and it stops nothing else", orderText(ghost), "a")

# ---------------------------------------------------------------------------
# 4. Sides and the pipeline range
# ---------------------------------------------------------------------------

proc sidesAndPipeline() =
  heading "The side a mod declares"
  var reg = emptyReg()
  reg.mods.add aMod("srv", "1.0.0", "*", @["server"])
  reg.mods.add aMod("cli", "1.0.0", "*", @["client"])
  reg.lists.add aList("l", @[], @[entry("srv", true), entry("cli", true)])
  let onServer = resolve(reg, @["l"], noOverrides(), noFlags(), "server",
                         "0.1.0")
  checkEq("a client-only mod is wrong-side on the server",
          verdictOf(onServer, "cli"), "wrong-side")
  checkEq("and says so in those words", reasonOf(onServer, "cli"),
          "declares no server side")
  let onClient = resolve(reg, @["l"], noOverrides(), noFlags(), "client",
                         "0.1.0")
  checkEq("the same registry resolves it on the client",
          verdictOf(onClient, "cli"), "loaded")
  checkEq("and the server-only mod is wrong-side there",
          verdictOf(onClient, "srv"), "wrong-side")
  let forced = resolve(reg, @["l"], @["cli"], @[true], "server", "0.1.0")
  checkEq("an explicit override cannot put a mod on a side it does not have",
          verdictOf(forced, "cli"), "wrong-side")

  heading "The pipeline range, against this host"
  var reg2 = emptyReg()
  reg2.mods.add aMod("new", "1.0.0", ">=0.2.0", @["server"])
  reg2.mods.add aMod("old", "1.0.0", ">=0.1.0", @["server"])
  reg2.mods.add aMod("broken", "1.0.0", "1.x", @["server"])
  reg2.lists.add aList("l", @[],
                       @[entry("new", true), entry("old", true),
                         entry("broken", true)])
  let r2 = resolve(reg2, @["l"], noOverrides(), noFlags(), "server", "0.1.0")
  checkEq("a mod that needs a newer pipeline is excluded",
          verdictOf(r2, "new"), "pipeline")
  check("and the reason names the range and this host",
        find(reasonOf(r2, "new"), ">=0.2.0") >= 0 and
        find(reasonOf(r2, "new"), "0.1.0") >= 0, reasonOf(r2, "new"))
  checkEq("one that fits is unaffected", verdictOf(r2, "old"), "loaded")
  checkEq("a range this reader cannot read excludes the mod",
          verdictOf(r2, "broken"), "pipeline")
  check("and is reported as a registry fault, naming the mod",
        r2.says("broken: "), problemsText(r2))
  check("the range check ran", r2.pipelineChecked, "pipelineChecked is false")

  heading "A host that misreports its own version"
  let r3 = resolve(reg2, @["l"], noOverrides(), noFlags(), "server", "wat")
  check("range checking is skipped once, loudly", not r3.pipelineChecked,
        "pipelineChecked is true")
  check("and says what the host claimed", r3.says("\"wat\""), problemsText(r3))
  checkEq("and no mod is punished for it", verdictOf(r3, "new"), "loaded")

# ---------------------------------------------------------------------------
# 5. requires
# ---------------------------------------------------------------------------

proc requiresRules() =
  heading "requires, and the version range on it"
  var reg = emptyReg()
  var dep = serverMod("dep")
  var user = serverMod("user")
  user.requires.add Requirement(id: "dep", versionRange: ">=1.0.0")
  reg.mods.add user
  reg.mods.add dep
  reg.lists.add aList("l", @[], @[entry("user", true), entry("dep", true)])
  let r = run(reg, @["l"])
  checkEq("a satisfied requirement loads both", verdictOf(r, "user"), "loaded")
  checkEq("and the dependency is emitted first, whatever the list order says",
          orderText(r), "dep,user")

  heading "A requirement that is not met"
  var reg2 = emptyReg()
  var u2 = serverMod("user")
  u2.requires.add Requirement(id: "dep", versionRange: "*")
  reg2.mods.add u2
  reg2.mods.add serverMod("dep")
  reg2.lists.add aList("l", @[], @[entry("user", true), entry("dep", false)])
  let r2 = run(reg2, @["l"])
  checkEq("a mod whose dependency is switched off is excluded",
          verdictOf(r2, "user"), "missing-dependency")
  checkEq("and says which one", reasonOf(r2, "user"),
          "needs dep, which is not loading here")
  checkEq("and the dependency is not switched back on for it",
          verdictOf(r2, "dep"), "disabled")
  checkEq("and nothing loads", orderText(r2), "")

  heading "A requirement at the wrong version"
  var reg3 = emptyReg()
  var u3 = serverMod("user")
  u3.requires.add Requirement(id: "dep", versionRange: ">=2.0.0")
  reg3.mods.add u3
  reg3.mods.add aMod("dep", "1.4.0", "*", @["server"])
  reg3.lists.add aList("l", @[], @[entry("user", true), entry("dep", true)])
  let r3 = run(reg3, @["l"])
  checkEq("a dependency at the wrong version excludes the dependent",
          verdictOf(r3, "user"), "missing-dependency")
  check("and the reason names the range and the version there is",
        find(reasonOf(r3, "user"), ">=2.0.0") >= 0 and
        find(reasonOf(r3, "user"), "1.4.0") >= 0, reasonOf(r3, "user"))
  checkEq("the dependency itself is unaffected", verdictOf(r3, "dep"), "loaded")

  heading "A dependency whose declared version is not a version"
  var reg4 = emptyReg()
  var u4 = serverMod("user")
  u4.requires.add Requirement(id: "dep", versionRange: ">=1.0.0")
  reg4.mods.add u4
  reg4.mods.add aMod("dep", "banana", "*", @["server"])
  reg4.lists.add aList("l", @[], @[entry("user", true), entry("dep", true)])
  let r4 = run(reg4, @["l"])
  checkEq("it excludes the dependent rather than being guessed at",
          verdictOf(r4, "user"), "missing-dependency")
  check("and quotes what the registry said", find(reasonOf(r4, "user"),
        "banana") >= 0, reasonOf(r4, "user"))

  heading "Exclusion cascades to a fixed point"
  var reg5 = emptyReg()
  var a5 = serverMod("a")
  a5.requires.add Requirement(id: "b", versionRange: "*")
  var b5 = serverMod("b")
  b5.requires.add Requirement(id: "c", versionRange: "*")
  reg5.mods.add a5
  reg5.mods.add b5
  reg5.mods.add serverMod("c")
  reg5.lists.add aList("l", @[],
                       @[entry("a", true), entry("b", true), entry("c", false)])
  let r5 = run(reg5, @["l"])
  checkEq("the mod that needed the excluded one goes too",
          verdictOf(r5, "b"), "missing-dependency")
  checkEq("and so does the one that needed that",
          verdictOf(r5, "a"), "missing-dependency")
  checkEq("and nothing is left loading", orderText(r5), "")

  heading "A requirement naming a mod the registry does not have"
  var reg6 = emptyReg()
  var u6 = serverMod("user")
  u6.requires.add Requirement(id: "nothing.at.all", versionRange: "*")
  reg6.mods.add u6
  reg6.lists.add aList("l", @[], @[entry("user", true)])
  let r6 = run(reg6, @["l"])
  checkEq("is a missing dependency and not a crash",
          verdictOf(r6, "user"), "missing-dependency")

# ---------------------------------------------------------------------------
# 6. conflicts and provides
# ---------------------------------------------------------------------------

proc conflictRules() =
  heading "Two mods that name each other"
  var reg = emptyReg()
  var a = serverMod("a")
  a.conflicts.add Conflict(id: "b", reason: "both own bot brains")
  reg.mods.add a
  reg.mods.add serverMod("b")
  reg.lists.add aList("l", @[], @[entry("a", true), entry("b", true)])
  let r = run(reg, @["l"])
  checkEq("neither of a declared conflict is loaded", orderText(r), "")
  checkEq("both are reported as a conflict", verdictOf(r, "a") & "/" &
          verdictOf(r, "b"), "conflict/conflict")
  check("and the registry's own reason is what is printed",
        find(reasonOf(r, "b"), "both own bot brains") >= 0, reasonOf(r, "b"))
  check("and it is said which one to disable",
        find(reasonOf(r, "a"), "disable one") >= 0, reasonOf(r, "a"))

  heading "The other direction counts too"
  var reg2 = emptyReg()
  reg2.mods.add serverMod("a")
  var b2 = serverMod("b")
  b2.conflicts.add Conflict(id: "a", reason: "declared by the other one")
  reg2.mods.add b2
  reg2.lists.add aList("l", @[], @[entry("a", true), entry("b", true)])
  let r2 = run(reg2, @["l"])
  checkEq("a mod that has not heard of the conflict is still excluded",
          verdictOf(r2, "a"), "conflict")

  heading "Two mods that provide the same capability"
  var reg3 = emptyReg()
  var a3 = serverMod("a")
  a3.provides.add "aowl.capability.ai"
  var b3 = serverMod("b")
  b3.provides.add "aowl.capability.ai"
  reg3.mods.add a3
  reg3.mods.add b3
  reg3.lists.add aList("l", @[], @[entry("a", true), entry("b", true)])
  let r3 = run(reg3, @["l"])
  checkEq("conflict without either having heard of the other",
          verdictOf(r3, "a"), "conflict")
  check("and the reason is the capability they share",
        find(reasonOf(r3, "a"), "both provide aowl.capability.ai") >= 0,
        reasonOf(r3, "a"))

  heading "Unless exactly one of them is your own decision"
  let r4 = runWith(reg3, @["l"], @["a"], @[true])
  checkEq("the one you enabled yourself wins", verdictOf(r4, "a"), "loaded")
  checkEq("and only the other is excluded", verdictOf(r4, "b"), "conflict")
  check("which is said in the reason", find(reasonOf(r4, "b"),
        "which you enabled yourself") >= 0, reasonOf(r4, "b"))
  let r5 = runWith(reg3, @["l"], @["a", "b"], @[true, true])
  checkEq("two explicit ones is not a preference, so both go",
          verdictOf(r5, "a") & "/" & verdictOf(r5, "b"), "conflict/conflict")

  heading "A conflict that strands a dependent"
  var reg6 = emptyReg()
  var dep = serverMod("dep")
  dep.provides.add "cap"
  var other = serverMod("other")
  other.provides.add "cap"
  var user = serverMod("user")
  user.requires.add Requirement(id: "dep", versionRange: "*")
  reg6.mods.add user
  reg6.mods.add dep
  reg6.mods.add other
  reg6.lists.add aList("l", @[], @[entry("user", true), entry("dep", true),
                                   entry("other", true)])
  let r6 = run(reg6, @["l"])
  checkEq("the conflict is resolved to the fixed point, not one pass",
          verdictOf(r6, "user"), "missing-dependency")
  checkEq("and nothing at all is loaded", orderText(r6), "")

# ---------------------------------------------------------------------------
# 7. loadAfter
# ---------------------------------------------------------------------------

proc loadAfterRules() =
  heading "loadAfter orders, and only orders"
  var reg = emptyReg()
  reg.mods.add serverMod("a")
  var b = serverMod("b")
  b.loadAfter.add "a"
  reg.mods.add b
  # The list says b first on purpose: `loadAfter` has to be able to beat the
  # list's own order, or it does nothing at all.
  reg.lists.add aList("l", @[], @[entry("b", true), entry("a", true)])
  let r = run(reg, @["l"])
  checkEq("a mod that loads after another is emitted after it",
          orderText(r), "a,b")

  heading "A loadAfter naming something that is not loading is ignored"
  var reg2 = emptyReg()
  var b2 = serverMod("b")
  b2.loadAfter.add "absent"
  b2.loadAfter.add "off"
  reg2.mods.add b2
  reg2.mods.add serverMod("off")
  reg2.lists.add aList("l", @[], @[entry("b", true), entry("off", false)])
  let r2 = run(reg2, @["l"])
  checkEq("a name nothing defines does not exclude the mod",
          verdictOf(r2, "b"), "loaded")
  checkEq("and neither does a name that is switched off", orderText(r2), "b")

# ---------------------------------------------------------------------------
# 8. Cycles -- the four kinds, each named rather than hung on
# ---------------------------------------------------------------------------

proc cycles() =
  heading "A list that inherits itself"
  var reg = emptyReg()
  reg.mods.add serverMod("a")
  reg.mods.add serverMod("b")
  reg.lists.add aList("loop", @["loop"], @[entry("a", true)])
  reg.lists.add aList("fine", @[], @[entry("b", true)])
  let r = run(reg, @["loop", "fine"])
  check("is refused with the cycle written out",
        r.says("loop -> loop"), problemsText(r))
  checkEq("the whole of that list contributes nothing",
          verdictOf(r, "a"), "not-selected")
  checkEq("and the other active list is unaffected", orderText(r), "b")

  heading "Two lists that inherit each other"
  var reg2 = emptyReg()
  reg2.mods.add serverMod("a")
  reg2.mods.add serverMod("b")
  reg2.mods.add serverMod("c")
  reg2.lists.add aList("one", @["two"], @[entry("a", true)])
  reg2.lists.add aList("two", @["one"], @[entry("b", true)])
  reg2.lists.add aList("fine", @[], @[entry("c", true)])
  let r2 = run(reg2, @["one", "fine"])
  check("is refused with both lists named, in order",
        r2.says("one -> two -> one"), problemsText(r2))
  checkEq("nothing from either of them is applied", orderText(r2), "c")
  check("and the list that was selected is named as contributing nothing",
        r2.says("the active list one contributes nothing"), problemsText(r2))

  heading "A three-list cycle reached from outside it"
  var reg3 = emptyReg()
  reg3.mods.add serverMod("a")
  reg3.lists.add aList("top", @["x"], @[entry("a", true)])
  reg3.lists.add aList("x", @["y"], @[])
  reg3.lists.add aList("y", @["x"], @[])
  let r3 = run(reg3, @["top"])
  check("names the cycle itself and not the list that led to it",
        r3.says("x -> y -> x"), problemsText(r3))
  checkEq("and the list that reached it contributes nothing either",
          orderText(r3), "")

  heading "A requires cycle"
  var reg4 = emptyReg()
  var a4 = serverMod("a")
  a4.requires.add Requirement(id: "b", versionRange: "*")
  var b4 = serverMod("b")
  b4.requires.add Requirement(id: "a", versionRange: "*")
  reg4.mods.add a4
  reg4.mods.add b4
  reg4.mods.add serverMod("safe")
  reg4.lists.add aList("l", @[], @[entry("a", true), entry("b", true),
                                   entry("safe", true)])
  let r4 = run(reg4, @["l"])
  checkEq("both mods in it are excluded as a cycle",
          verdictOf(r4, "a") & "/" & verdictOf(r4, "b"), "cycle/cycle")
  # Both members named, and the sentence that names them. `says("a")` was what
  # this used to ask for, and "a" is a substring of almost every problem string
  # the resolver can produce -- including several that have nothing to do with a
  # cycle -- so the check held whatever came back. It has to be the mods, by id,
  # in the message the resolver writes for this case.
  check("and the cycle is named, with both mods in it",
        r4.says("a dependency cycle among ") and r4.says("a, b"),
        problemsText(r4))
  # And the mod that is *not* in the cycle is not named in it, which is the
  # other half of "named": a message listing every mod would satisfy the check
  # above and tell a reader nothing.
  check("and the mod outside it is not",
        find(problemsText(r4), "safe") < 0, problemsText(r4))
  checkEq("a mod that is not in the cycle still loads", orderText(r4), "safe")

  heading "A mod that requires itself"
  var reg5 = emptyReg()
  var a5 = serverMod("a")
  a5.requires.add Requirement(id: "a", versionRange: "*")
  reg5.mods.add a5
  reg5.lists.add aList("l", @[], @[entry("a", true)])
  let r5 = run(reg5, @["l"])
  checkEq("is a cycle rather than a mod that satisfies itself",
          verdictOf(r5, "a"), "cycle")

  heading "A loadAfter cycle"
  var reg6 = emptyReg()
  var a6 = serverMod("a")
  a6.loadAfter.add "b"
  var b6 = serverMod("b")
  b6.loadAfter.add "a"
  reg6.mods.add a6
  reg6.mods.add b6
  reg6.lists.add aList("l", @[], @[entry("a", true), entry("b", true)])
  let r6 = run(reg6, @["l"])
  checkEq("is refused rather than resolved in an arbitrary order",
          verdictOf(r6, "a") & "/" & verdictOf(r6, "b"), "cycle/cycle")
  check("and named, with both mods in it",
        r6.says("a dependency cycle among ") and r6.says("a, b"),
        problemsText(r6))

# ---------------------------------------------------------------------------
# 9. It is a function
# ---------------------------------------------------------------------------

proc determinism() =
  heading "Same input, same answer"
  var reg = emptyReg()
  var a = serverMod("a")
  a.requires.add Requirement(id: "dep", versionRange: "*")
  a.loadAfter.add "late"
  reg.mods.add a
  reg.mods.add serverMod("dep")
  reg.mods.add serverMod("late")
  reg.mods.add serverMod("spare")
  reg.lists.add aList("base", @[], @[entry("late", true), entry("dep", true)])
  reg.lists.add aList("l", @["base"], @[entry("a", true),
                                        entry("spare", false)])
  let first = runWith(reg, @["l"], @["spare"], @[true])
  let second = runWith(reg, @["l"], @["spare"], @[true])
  checkEq("the order is identical on a second run", orderText(second),
          orderText(first))
  checkEq("and so is every verdict",
          verdictOf(second, "a") & verdictOf(second, "dep") &
          verdictOf(second, "late") & verdictOf(second, "spare"),
          verdictOf(first, "a") & verdictOf(first, "dep") &
          verdictOf(first, "late") & verdictOf(first, "spare"))
  check("and the answer is the one the rules describe",
        orderText(first) == "late,dep,a,spare" or
        orderText(first) == "dep,late,a,spare", orderText(first))

# ---------------------------------------------------------------------------
# 10. Reading a manifest that has something wrong with it
# ---------------------------------------------------------------------------

proc manifests() =
  heading "A registry whose schema this reader does not know"
  let wrong = parseRegistry("{\"schema\":\"something/2\",\"mods\":[]}", "m.json")
  check("is refused whole rather than half-read", not wrong.ok, wrong.error)
  check("and the error quotes both schemas",
        find(wrong.error, "something/2") >= 0 and
        find(wrong.error, SchemaId) >= 0, wrong.error)

  heading "A registry that is not a registry"
  check("an empty file is refused", not parseRegistry("", "m.json").ok, "")
  check("so is a JSON array", not parseRegistry("[]", "m.json").ok, "")
  check("so is a truncated object",
        not parseRegistry("{\"schema\":", "m.json").ok, "")

  heading "The same guid twice"
  let dup = parseRegistry("{\"schema\":\"" & SchemaId & "\",\"mods\":[" &
    "{\"id\":\"a\",\"version\":\"1.0.0\",\"sides\":[\"server\"]," &
    "\"artifact\":{\"dir\":\"a\",\"library\":\"a.dll\"}}," &
    "{\"id\":\"a\",\"version\":\"9.9.9\",\"sides\":[\"server\"]," &
    "\"artifact\":{\"dir\":\"b\",\"library\":\"b.dll\"}}]}", "m.json")
  check("is read, with the duplicate ignored", dup.ok, dup.error)
  check("exactly once", dup.mods.len == 1, $dup.mods.len & " entries")
  checkEq("and the first one is the one kept", dup.mods[0].version, "1.0.0")
  check("and it is said out loud rather than resolved silently",
        find(warningsText(dup), "appears twice") >= 0, warningsText(dup))

  heading "A mod with no artifact"
  let noArt = parseRegistry("{\"schema\":\"" & SchemaId & "\",\"mods\":[" &
    "{\"id\":\"a\",\"version\":\"1.0.0\",\"sides\":[\"server\"]}]}", "m.json")
  check("is read", noArt.ok, noArt.error)
  check("and warned about at load, naming what cannot be done with it",
        find(warningsText(noArt), "never loaded or unloaded") >= 0,
        warningsText(noArt))
  # It still resolves: the manager can say it is enabled, and says `refused`
  # with that sentence when something tries to load it. Resolution and
  # loadability are different questions and the registry answers both.
  var reg = noArt
  reg.lists.add aList("l", @[], @[entry("a", true)])
  checkEq("and still resolves, because resolving is not loading",
          orderText(run(reg, @["l"])), "a")

  heading "Entries with pieces missing"
  let partial = parseRegistry("{\"schema\":\"" & SchemaId & "\",\"mods\":[" &
    "{\"version\":\"1.0.0\"}," &
    "{\"id\":\"b\",\"version\":\"1.0.0\",\"sides\":[\"server\"]," &
    "\"license\":null,\"download\":null," &
    "\"requires\":[{\"version\":\"*\"}]," &
    "\"artifact\":{\"dir\":\"b\",\"library\":\"b.dll\"}}]}", "m.json")
  check("a mod with no id is skipped and said", partial.mods.len == 1 and
        find(warningsText(partial), "no id") >= 0, warningsText(partial))
  check("a requires entry with no id is dropped, not guessed at",
        partial.mods[0].requires.len == 0 and
        find(warningsText(partial), "`requires` entry has no id") >= 0,
        warningsText(partial))
  checkEq("a null string field reads as absent, not as the word null",
          partial.mods[0].license, "")
  checkEq("including a download url, which is the one that matters",
          partial.mods[0].downloadUrl, "")

# ---------------------------------------------------------------------------
# 11. Versions and ranges
# ---------------------------------------------------------------------------

proc versions() =
  heading "Versions"
  check("1.2.3 parses", parseVersion("1.2.3").ok, "")
  check("a prerelease suffix is ignored rather than refused",
        parseVersion("1.2.3-beta.1").ok, "")
  check("1.2 is refused rather than read as 1.2.0",
        not parseVersion("1.2").ok, "")
  check("1.2.3.4 is refused", not parseVersion("1.2.3.4").ok, "")
  check("1..2 is refused", not parseVersion("1..2").ok, "")
  check("an empty string is refused", not parseVersion("").ok, "")
  check("and so is a word", not parseVersion("latest").ok, "")

  heading "Ranges"
  let v = parseVersion("1.2.3")
  var e = ""
  check("* accepts anything", matchRange(v, "*", e), e)
  check("an empty range accepts anything", matchRange(v, "", e), e)
  check("an exact match", matchRange(v, "1.2.3", e), e)
  check("=1.2.3", matchRange(v, "=1.2.3", e), e)
  check(">=1.0.0", matchRange(v, ">=1.0.0", e), e)
  check("not >=2.0.0", not matchRange(v, ">=2.0.0", e), e)
  check("<2.0.0", matchRange(v, "<2.0.0", e), e)
  check("two terms are ANDed", matchRange(v, ">=1.0.0 <2.0.0", e), e)
  check("and both have to hold", not matchRange(v, ">=1.0.0 <1.2.0", e), e)
  check("~1.2.0 takes a patch bump", matchRange(v, "~1.2.0", e), e)
  check("~1.1.0 does not take a minor bump",
        not matchRange(v, "~1.1.0", e), e)
  check("^1.0.0 takes a minor bump", matchRange(v, "^1.0.0", e), e)
  check("^0.1.0 does not, when the major is 0",
        not matchRange(parseVersion("0.2.0"), "^0.1.0", e), e)
  check("|| is refused rather than approximated",
        not matchRange(v, "1.0.0 || 2.0.0", e) and find(e, "||") >= 0, e)
  check("and an operator nobody implemented is refused by name",
        not matchRange(v, "!1.2.3", e) and e.len > 0, e)

# ---------------------------------------------------------------------------
# 12. A selection file that is damaged
# ---------------------------------------------------------------------------

proc selectionDocs() =
  heading "What the manager will act on"
  checkEq("a selection this manager wrote",
          selectionFaultIn("{\"lists\":[\"a\"],\"overrides\":[],\"local\":[]}"),
          "")
  checkEq("one with only overrides in it",
          selectionFaultIn("{\"overrides\":[{\"id\":\"a\",\"enabled\":false}]}"),
          "")
  checkEq("an empty selection is a real selection: everything off",
          selectionFaultIn("{\"lists\":[],\"overrides\":[],\"local\":[]}"), "")
  checkEq("a brace inside a string is not a brace",
          selectionFaultIn("{\"lists\":[\"a}b{c\"]}"), "")
  checkEq("nor is an escaped quote the end of one",
          selectionFaultIn("{\"lists\":[\"a\\\"b\"]}"), "")

  heading "What it refuses, rather than reading as an empty setup"
  check("nothing at all", selectionFaultIn("").len > 0, "")
  check("truncated in the middle of an array",
        selectionFaultIn("{\"lists\":[\"raidnight").len > 0, "")
  check("truncated one byte from the end",
        selectionFaultIn("{\"lists\":[\"a\"]").len > 0, "")
  check("truncated inside a string, mid-escape",
        selectionFaultIn("{\"lists\":[\"a\\").len > 0, "")
  check("a JSON array where an object belongs",
        selectionFaultIn("[]").len > 0, "")
  check("a bare string", selectionFaultIn("\"lists\"").len > 0, "")
  check("an object with nothing of ours in it",
        selectionFaultIn("{}").len > 0, "")
  check("an object that is somebody else's document",
        selectionFaultIn("{\"profile\":{\"nickname\":\"x\"}}").len > 0, "")
  check("a second document glued onto the end",
        selectionFaultIn("{\"lists\":[]} {\"lists\":[]}").len > 0, "")
  check("trailing bytes after the object",
        selectionFaultIn("{\"lists\":[]}garbage").len > 0, "")
  check("a NUL in the middle of it",
        selectionFaultIn("{\"lists\":[\"a\"" & $chr(0) & "]}").len > 0, "")
  check("a closing brace too many",
        selectionFaultIn("{\"lists\":[]}}").len > 0, "")
  check("lists that is not an array",
        find(selectionFaultIn("{\"lists\":\"vanilla\"}"), "not an array") >= 0,
        selectionFaultIn("{\"lists\":\"vanilla\"}"))
  check("overrides that is not an array",
        selectionFaultIn("{\"lists\":[],\"overrides\":{}}").len > 0, "")
  check("local that is not an array",
        selectionFaultIn("{\"lists\":[],\"local\":7}").len > 0, "")
  # The one that decided the shape of all of the above: a document that parses
  # as "no lists and no overrides" is indistinguishable from a person having
  # switched everything off, and the manager persists over it on the next
  # change. Every fault above has to be a *fault*, not an empty read.
  check("and the fault always says something, so the log can name it",
        selectionFaultIn("{\"lists\":[\"a\"").len > 4, "")

# ---------------------------------------------------------------------------
# 13. Ids arriving from outside
# ---------------------------------------------------------------------------

proc ids() =
  heading "What is allowed to be an id"
  checkEq("a reverse-DNS mod id", idFault("aowl.tarkov"), "")
  checkEq("with digits, dashes and underscores",
          idFault("aowl.mod-2_x.99"), "")
  check("nothing is not an id", idFault("").len > 0, "")
  check("a quote is not part of an id", idFault("a\"b").len > 0, "")
  check("neither is a backslash", idFault("a\\b").len > 0, "")
  check("nor a NUL", idFault("a" & $chr(0) & "b").len > 0, "")
  check("nor a byte that is not UTF-8 at all",
        idFault("a" & $chr(255) & "b").len > 0, "")
  check("nor a newline", idFault("a\nb").len > 0, "")
  check("nor a space", idFault("a b").len > 0, "")
  check("nor a slash, which would be a path",
        idFault("../../etc/passwd").len > 0, "")
  var long = ""
  for i in 0 ..< 4096:
    long.add "a"
  check("and four kilobytes of id is not an id", idFault(long).len > 0, "")
  check("with the limit said in the refusal",
        find(idFault(long), "80") >= 0, idFault(long))
  check("81 bytes is over the line", idFault(long.substr(0, 80)).len > 0, "")
  checkEq("and 80 is not", idFault(long.substr(0, 79)), "")

# ---------------------------------------------------------------------------

proc main(): int =
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "-q" or a == "--quiet":
      gQuiet = true
    elif a == "-h" or a == "--help":
      echo "modresolve -- the mod manager's rules, without a server"
      return 0
    else:
      err "unknown option: " & a
      return 1
    inc i

  theBasics()
  inheritance()
  overrides()
  sidesAndPipeline()
  requiresRules()
  conflictRules()
  loadAfterRules()
  cycles()
  determinism()
  manifests()
  versions()
  selectionDocs()
  ids()

  heading "Result"
  if gFailures > 0:
    err $gFailures & " of " & $gChecks & " failed"
    return 1
  ok "the resolver answered all " & $gChecks & " checks"
  result = 0

quit(main())
